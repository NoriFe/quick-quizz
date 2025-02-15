require 'open-uri'
require 'retryable'

class Quiz < ApplicationRecord
  has_one_attached :image
  belongs_to :user
  has_many :questions, dependent: :destroy
  has_many :quiz_results, dependent: :destroy
  has_many :quiz_takers, through: :quiz_results, source: :user

  attr_accessor :text, :content, :seed

  after_commit :generate_quiz, on: [:create], unless: :seed

  private

  def generate_quiz
    if image.attached?
      temp = Tempfile.new ["image", ".jpg"], Rails.root.join('tmp')
      temp.binmode
      temp.write(URI.open(image.url).read)
      temp.rewind
      image_text = RTesseract.new(temp.path).to_s
      self.text = image_text
    end
    # creating backoff questions
    response = get_ai_answer_with_retry
    response.each do |question|
      new_question = Question.new(
        question: question['question'],
        content: question['options'],
        quiz: self
      )
      new_question.save!
      new_question.generate_choices(question)
    end
  end

  def get_ai_answer_with_retry
    Retryable.retryable(tries: 3, on: StandardError, sleep: ->(n) { 2**n }) do
      get_ai_answer
    end
  end



  def get_ai_answer
    client = OpenAI::Client.new
    chatgpt_response = client.chat(
      parameters: {
        model: "gpt-3.5-turbo-0125",
        messages: [
          {
            role: "system",
            content: "You are a helpful assistant that generates quiz questions based on the provided content. Respond with five short questions and four plausible options/ answers for each question, of which only one is correct. Provide your answer in a  JSON structure similar to this.
                      [
                        {
                          'topic: '<The topic of the quiz>',
                          'question': '<The quiz question you generate>',
                          'options': {
                            'option1': {'body': '<Plausible option 1>', 'isItCorrect': <true or false>},
                            'option2': {'body': '<Plausible option 2>', 'isItCorrect': <true or false>},
                            'option3': {'body': '<Plausible option 3>', 'isItCorrect': <true or false>},
                            'option4': {'body': '<Plausible option 4>', 'isItCorrect': <true or false>}
                          }
                        },
                        {
                          'topic: '<The topic of the quiz>',
                          'question': '<The quiz question you generate>',
                          'options': {
                            'option1': {'body': '<Plausible option 1>', 'isItCorrect': <true or false>},
                            'option2': {'body': '<Plausible option 2>', 'isItCorrect': <true or false>},
                            'option3': {'body': '<Plausible option 3>', 'isItCorrect': <true or false>},
                            'option4': {'body': '<Plausible option 4>', 'isItCorrect': <true or false>}
                          }
                        }
                      ]
                      Under no circumstances use double quotes in your JSON response. Use single quotes instead.
                      Do not put any words or phrases in quotes in your response.
                      Under no circumstances use apostrophes in your response.
                      If you use double quotes, the JSON will be invalid and an error will occur. If you are unsure about the JSON structure, please refer to the example above."
          },
          {
            role: "user",
            content: "Generate a multiple choice quiz about: #{text}. Give me only the text of the quiz, without any of your own answer like 'Here is a quiz I made'."
          },
          {
            role: "assistant",
            content: "{'topic': 'Premier League location', 'question': 'Where is the Premier League played?',
                      'options': {'option1': {'body': 'France', 'isItCorrect': false}, 'option2': {'body': 'England', 'isItCorrect': true}, 'option3': {'body': 'Sweden', 'isItCorrect': false}}}'"
          }
        ]
      }
    )

    raw_content = chatgpt_response['choices'][0]['message']['content'].gsub("\\'", "AAA").gsub('"', '\\"').gsub("'", '"').gsub("AAA", "'")
    response = JSON.parse(raw_content)

    update_columns(title: response[0]["topic"])

    return response
  end
end
